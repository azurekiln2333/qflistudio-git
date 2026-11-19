/*
 * Copyright (C) 2026 the qfli_git authors.
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 3 of the License, or (at your
 * option) any later version.
 */

#include "qfli_git.h"

#include <git2.h>
#include <mbedtls/build_info.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct qg_repo {
	git_repository *repo;
};

/* ---------------------------------------------------------------------- */
/* errors                                                                  */
/* ---------------------------------------------------------------------- */

static int qg_canceled(const int32_t *flag)
{
	const volatile int32_t *value = flag;

	return value != NULL && *value != 0;
}

static int qg_error_set(qg_error *err, int code, int klass, const char *message)
{
	if (err != NULL) {
		err->code = code;
		err->klass = klass;
		if (message == NULL)
			message = "";
		snprintf(err->message, sizeof(err->message), "%s", message);
	}

	return code;
}

/* Fill err from the last libgit2 error and return code. */
static int qg_error_libgit2(qg_error *err, int code)
{
	const git_error *last = git_error_last();

	if (last != NULL)
		return qg_error_set(err, code, last->klass, last->message);

	return qg_error_set(err, code, 0, "libgit2 error");
}

static int qg_error_string(qg_error *err, int code, const char *message)
{
	return qg_error_set(err, code, 0, message);
}

/*
 * Turn a libgit2 return code into the qg contract: a cancelled operation
 * always reports QG_ECANCELED, whatever libgit2 raised underneath.
 */
static int qg_result(int code, const int32_t *cancel_flag, qg_error *err)
{
	if (code >= 0)
		return code;

	if (qg_canceled(cancel_flag))
		return qg_error_string(err, QG_ECANCELED, "operation canceled");

	return qg_error_libgit2(err, code);
}

static int qg_invalid(qg_error *err, const char *message)
{
	return qg_error_string(err, QG_EINVALID, message);
}

/* ---------------------------------------------------------------------- */
/* string buffer and JSON                                                  */
/* ---------------------------------------------------------------------- */

typedef struct {
	char *data;
	size_t length;
	size_t capacity;
} qg_buffer;

static int qg_buffer_reserve(qg_buffer *buf, size_t extra)
{
	size_t needed = buf->length + extra + 1;
	char *grown;

	if (needed <= buf->capacity)
		return 0;

	if (buf->capacity == 0)
		buf->capacity = 128;
	while (buf->capacity < needed)
		buf->capacity *= 2;

	grown = realloc(buf->data, buf->capacity);
	if (grown == NULL)
		return -1;

	buf->data = grown;
	return 0;
}

static int qg_buffer_append(qg_buffer *buf, const char *text)
{
	size_t length;

	if (text == NULL)
		return 0;

	length = strlen(text);
	if (qg_buffer_reserve(buf, length) < 0)
		return -1;

	memcpy(buf->data + buf->length, text, length);
	buf->length += length;
	buf->data[buf->length] = '\0';
	return 0;
}

static int qg_buffer_append_json_string(qg_buffer *buf, const char *text)
{
	const unsigned char *cursor;

	if (qg_buffer_append(buf, "\"") < 0)
		return -1;

	for (cursor = (const unsigned char *)(text != NULL ? text : ""); *cursor; cursor++) {
		char escaped[8];

		switch (*cursor) {
		case '"':
			if (qg_buffer_append(buf, "\\\"") < 0)
				return -1;
			break;
		case '\\':
			if (qg_buffer_append(buf, "\\\\") < 0)
				return -1;
			break;
		case '\n':
			if (qg_buffer_append(buf, "\\n") < 0)
				return -1;
			break;
		case '\r':
			if (qg_buffer_append(buf, "\\r") < 0)
				return -1;
			break;
		case '\t':
			if (qg_buffer_append(buf, "\\t") < 0)
				return -1;
			break;
		default:
			if (*cursor < 0x20) {
				snprintf(escaped, sizeof(escaped), "\\u%04x", *cursor);
				if (qg_buffer_append(buf, escaped) < 0)
					return -1;
			} else {
				if (qg_buffer_reserve(buf, 1) < 0)
					return -1;
				buf->data[buf->length++] = (char)*cursor;
				buf->data[buf->length] = '\0';
			}
			break;
		}
	}

	return qg_buffer_append(buf, "\"");
}

static void qg_buffer_dispose(qg_buffer *buf)
{
	free(buf->data);
	buf->data = NULL;
	buf->length = 0;
	buf->capacity = 0;
}

/* Hand the buffer to the caller as a malloc'd string. */
static int qg_buffer_release(qg_buffer *buf, char **out)
{
	if (buf->data == NULL) {
		buf->data = malloc(1);
		if (buf->data == NULL)
			return -1;
		buf->data[0] = '\0';
	}

	*out = buf->data;
	buf->data = NULL;
	buf->length = 0;
	buf->capacity = 0;
	return 0;
}

/* ---------------------------------------------------------------------- */
/* network callbacks                                                       */
/* ---------------------------------------------------------------------- */

typedef struct {
	const char *username;
	const char *token;
	const int32_t *cancel_flag;
	int attempts;
} qg_callbacks;

static void qg_callbacks_init(qg_callbacks *cb, const char *username, const char *token,
                              const int32_t *cancel_flag)
{
	memset(cb, 0, sizeof(*cb));
	cb->username = username;
	cb->token = token;
	cb->cancel_flag = cancel_flag;
}

static int qg_credentials_cb(git_credential **out, const char *url, const char *username_from_url,
                             unsigned int allowed_types, void *payload)
{
	qg_callbacks *cb = (qg_callbacks *)payload;
	const char *username;

	(void)url;
	(void)username_from_url;
	(void)allowed_types;

	if (cb == NULL || cb->token == NULL || cb->token[0] == '\0')
		return GIT_EAUTH;

	/* A second attempt with the same credentials would loop forever. */
	if (cb->attempts++ > 0)
		return GIT_EAUTH;

	if (qg_canceled(cb->cancel_flag))
		return GIT_EUSER;

	/* The URL may carry a user name; the contract says to ignore it. */
	username = cb->username;
	if (username == NULL || username[0] == '\0')
		username = "git";

	return git_credential_userpass_plaintext_new(out, username, cb->token);
}

static int qg_transfer_progress_cb(const git_indexer_progress *stats, void *payload)
{
	qg_callbacks *cb = (qg_callbacks *)payload;

	(void)stats;

	if (cb != NULL && qg_canceled(cb->cancel_flag))
		return GIT_EUSER;

	return 0;
}

static int qg_push_transfer_progress_cb(unsigned int current, unsigned int total, size_t bytes,
                                        void *payload)
{
	qg_callbacks *cb = (qg_callbacks *)payload;

	(void)current;
	(void)total;
	(void)bytes;

	if (cb != NULL && qg_canceled(cb->cancel_flag))
		return GIT_EUSER;

	return 0;
}

static void qg_install_callbacks(git_remote_callbacks *callbacks, qg_callbacks *cb)
{
	memset(callbacks, 0, sizeof(*callbacks));
	callbacks->version = GIT_REMOTE_CALLBACKS_VERSION;
	callbacks->payload = cb;
	callbacks->credentials = qg_credentials_cb;
	callbacks->transfer_progress = qg_transfer_progress_cb;
	callbacks->push_transfer_progress = qg_push_transfer_progress_cb;
}

/* ---------------------------------------------------------------------- */
/* versions and lifecycle                                                  */
/* ---------------------------------------------------------------------- */

int qg_api_version(void)
{
	return QG_API_VERSION;
}

const char *qg_libgit2_version(void)
{
	return LIBGIT2_VERSION;
}

const char *qg_mbedtls_version(void)
{
	return MBEDTLS_VERSION_STRING;
}

int qg_init(const char *ca_file, qg_error *err)
{
	int rc;

	if (ca_file != NULL && ca_file[0] == '\0')
		ca_file = NULL;

	rc = git_libgit2_init();
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	if (ca_file != NULL) {
		rc = git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, ca_file, NULL);
		if (rc < 0) {
			git_libgit2_shutdown();
			return qg_error_libgit2(err, rc);
		}
	}

	return 0;
}

int qg_shutdown(void)
{
	int rc = git_libgit2_shutdown();

	if (rc < 0)
		return QG_EINVALID;

	return 0;
}

/* ---------------------------------------------------------------------- */
/* repositories                                                            */
/* ---------------------------------------------------------------------- */

static int qg_repo_wrap(git_repository *repository, qg_repo **out, qg_error *err)
{
	qg_repo *handle = calloc(1, sizeof(*handle));

	if (handle == NULL) {
		git_repository_free(repository);
		return qg_error_string(err, -1, "out of memory");
	}

	handle->repo = repository;
	*out = handle;
	return 0;
}

int qg_repo_init(const char *path, int bare, qg_repo **out, qg_error *err)
{
	git_repository *repository = NULL;
	int rc;

	if (path == NULL || out == NULL)
		return qg_invalid(err, "path and out are required");

	*out = NULL;

	rc = git_repository_init(&repository, path, bare ? 1 : 0);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	return qg_repo_wrap(repository, out, err);
}

int qg_repo_open(const char *path, qg_repo **out, qg_error *err)
{
	git_repository *repository = NULL;
	int rc;

	if (path == NULL || out == NULL)
		return qg_invalid(err, "path and out are required");

	*out = NULL;

	rc = git_repository_open(&repository, path);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	return qg_repo_wrap(repository, out, err);
}

void qg_repo_free(qg_repo *repo)
{
	if (repo == NULL)
		return;

	git_repository_free(repo->repo);
	free(repo);
}

/* ---------------------------------------------------------------------- */
/* clone, fetch, push                                                      */
/* ---------------------------------------------------------------------- */

int qg_clone(const char *url, const char *path, const char *username, const char *token,
             const int32_t *cancel_flag, qg_repo **out, qg_error *err)
{
	git_clone_options options = GIT_CLONE_OPTIONS_INIT;
	qg_callbacks cb;
	git_repository *repository = NULL;
	int rc;

	if (url == NULL || path == NULL || out == NULL)
		return qg_invalid(err, "url, path and out are required");

	*out = NULL;

	qg_callbacks_init(&cb, username, token, cancel_flag);
	qg_install_callbacks(&options.fetch_opts.callbacks, &cb);

	rc = git_clone(&repository, url, path, &options);
	if (rc < 0)
		return qg_result(rc, cancel_flag, err);

	return qg_repo_wrap(repository, out, err);
}

int qg_fetch(qg_repo *repo, const char *remote, const char *username, const char *token,
             const int32_t *cancel_flag, qg_error *err)
{
	git_fetch_options options = GIT_FETCH_OPTIONS_INIT;
	git_remote *handle = NULL;
	qg_callbacks cb;
	int rc;

	if (repo == NULL)
		return qg_invalid(err, "repo is required");

	if (remote == NULL)
		remote = "origin";

	qg_callbacks_init(&cb, username, token, cancel_flag);
	qg_install_callbacks(&options.callbacks, &cb);

	rc = git_remote_lookup(&handle, repo->repo, remote);
	if (rc < 0)
		return qg_result(rc, cancel_flag, err);

	rc = git_remote_fetch(handle, NULL, &options, NULL);
	git_remote_free(handle);

	return qg_result(rc, cancel_flag, err);
}

int qg_push(qg_repo *repo, const char *remote, const char *refspec, const char *username,
            const char *token, const int32_t *cancel_flag, qg_error *err)
{
	git_push_options options = GIT_PUSH_OPTIONS_INIT;
	git_remote *handle = NULL;
	qg_callbacks cb;
	git_strarray refspecs;
	char *items[1];
	int rc;

	if (repo == NULL || refspec == NULL)
		return qg_invalid(err, "repo and refspec are required");

	if (remote == NULL)
		remote = "origin";

	items[0] = (char *)refspec;
	refspecs.strings = items;
	refspecs.count = 1;

	qg_callbacks_init(&cb, username, token, cancel_flag);
	qg_install_callbacks(&options.callbacks, &cb);

	rc = git_remote_lookup(&handle, repo->repo, remote);
	if (rc < 0)
		return qg_result(rc, cancel_flag, err);

	rc = git_remote_push(handle, &refspecs, &options);
	git_remote_free(handle);

	return qg_result(rc, cancel_flag, err);
}

/* ---------------------------------------------------------------------- */
/* local operations                                                        */
/* ---------------------------------------------------------------------- */

int qg_add_all(qg_repo *repo, qg_error *err)
{
	git_index *index = NULL;
	int rc;

	if (repo == NULL)
		return qg_invalid(err, "repo is required");

	rc = git_repository_index(&index, repo->repo);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = git_index_add_all(index, NULL, GIT_INDEX_ADD_DEFAULT, NULL, NULL);
	if (rc >= 0)
		rc = git_index_update_all(index, NULL, NULL, NULL);
	if (rc >= 0)
		rc = git_index_write(index);

	git_index_free(index);
	return qg_result(rc, NULL, err);
}

static int qg_index_tree(git_tree **out, git_index *index, git_repository *repository,
                         qg_error *err)
{
	git_oid tree_id;
	int rc;

	rc = git_index_write(index);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = git_index_write_tree(&tree_id, index);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = git_tree_lookup(out, repository, &tree_id);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	if (*out == NULL)
		return qg_error_string(err, -1, "cannot write tree");

	return 0;
}

/* Commit the current index. parents may be NULL. */
static int qg_write_commit(qg_repo *repo, const char *message, const char *name,
                           const char *email, const git_commit *extra_parent,
                           git_oid *out_oid, qg_error *err)
{
	git_index *index = NULL;
	git_tree *tree = NULL;
	git_reference *head = NULL;
	git_commit *parent = NULL;
	git_commit *extra = (git_commit *)extra_parent;
	git_signature *signature = NULL;
	const git_commit *parents[2];
	size_t parent_count = 0;
	int rc;

	rc = git_repository_index(&index, repo->repo);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = qg_index_tree(&tree, index, repo->repo, err);
	git_index_free(index);
	if (rc < 0)
		return rc;

	rc = git_repository_head(&head, repo->repo);
	if (rc == 0) {
		rc = git_reference_peel((git_object **)&parent, head, GIT_OBJECT_COMMIT);
		git_reference_free(head);
		if (rc < 0) {
			git_tree_free(tree);
			return qg_error_libgit2(err, rc);
		}
		parents[parent_count++] = parent;
	} else if (rc != GIT_EUNBORNBRANCH && rc != GIT_ENOTFOUND) {
		git_tree_free(tree);
		return qg_error_libgit2(err, rc);
	}

	if (extra != NULL)
		parents[parent_count++] = extra;

	rc = git_signature_now(&signature, name, email);
	if (rc < 0) {
		git_commit_free(parent);
		git_tree_free(tree);
		return qg_error_libgit2(err, rc);
	}

	rc = git_commit_create(out_oid, repo->repo, "HEAD", signature, signature, NULL, message,
	                       tree, parent_count, parents);

	git_signature_free(signature);
	git_commit_free(parent);
	git_tree_free(tree);

	if (rc < 0)
		return qg_error_libgit2(err, rc);

	return 0;
}

int qg_commit(qg_repo *repo, const char *message, const char *name, const char *email,
              char out_oid[41], qg_error *err)
{
	git_oid oid;
	int rc;

	if (repo == NULL || message == NULL || name == NULL || email == NULL || out_oid == NULL)
		return qg_invalid(err, "repo, message, name, email and out_oid are required");

	rc = qg_write_commit(repo, message, name, email, NULL, &oid, err);
	if (rc < 0)
		return rc;

	git_oid_tostr(out_oid, 41, &oid);
	return 0;
}

int qg_branch_create(qg_repo *repo, const char *name, const char *start_point, qg_error *err)
{
	git_reference *reference = NULL;
	git_object *object = NULL;
	git_commit *target = NULL;
	git_reference *head = NULL;
	int rc;

	if (repo == NULL || name == NULL)
		return qg_invalid(err, "repo and name are required");

	if (start_point != NULL && start_point[0] != '\0') {
		rc = git_revparse_single(&object, repo->repo, start_point);
		if (rc < 0)
			return qg_error_libgit2(err, rc);
	} else {
		rc = git_repository_head(&head, repo->repo);
		if (rc < 0)
			return qg_error_libgit2(err, rc);
		rc = git_reference_peel(&object, head, GIT_OBJECT_COMMIT);
		git_reference_free(head);
		if (rc < 0)
			return qg_error_libgit2(err, rc);
	}

	rc = git_object_peel((git_object **)&target, object, GIT_OBJECT_COMMIT);
	git_object_free(object);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = git_branch_create(&reference, repo->repo, name, target, 0);
	git_commit_free(target);
	git_reference_free(reference);

	return qg_result(rc, NULL, err);
}

int qg_checkout_branch(qg_repo *repo, const char *name, qg_error *err)
{
	git_reference *reference = NULL;
	git_object *target = NULL;
	git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
	const char *refname;
	int rc;

	if (repo == NULL || name == NULL)
		return qg_invalid(err, "repo and name are required");

	rc = git_branch_lookup(&reference, repo->repo, name, GIT_BRANCH_LOCAL);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	refname = git_reference_name(reference);

	rc = git_reference_peel(&target, reference, GIT_OBJECT_COMMIT);
	if (rc < 0) {
		git_reference_free(reference);
		return qg_error_libgit2(err, rc);
	}

	options.checkout_strategy = GIT_CHECKOUT_SAFE;

	rc = git_checkout_tree(repo->repo, target, &options);
	if (rc >= 0)
		rc = git_repository_set_head(repo->repo, refname);

	git_object_free(target);
	git_reference_free(reference);

	return qg_result(rc, NULL, err);
}

/* ---------------------------------------------------------------------- */
/* merge                                                                   */
/* ---------------------------------------------------------------------- */

static int qg_merge_head_path(qg_repo *repo, char *path, size_t size, qg_error *err)
{
	const char *repo_path = git_repository_path(repo->repo);
	int written;

	if (repo_path == NULL)
		return qg_error_string(err, -1, "repository has no path");

	written = snprintf(path, size, "%sMERGE_HEAD", repo_path);
	if (written < 0 || (size_t)written >= size)
		return qg_error_string(err, -1, "repository path is too long");

	return 0;
}

static int qg_write_merge_head(qg_repo *repo, const git_oid *oid, qg_error *err)
{
	char path[4096];
	char hex[GIT_OID_SHA1_HEXSIZE + 1];
	FILE *file;
	int rc;

	rc = qg_merge_head_path(repo, path, sizeof(path), err);
	if (rc < 0)
		return rc;

	git_oid_tostr(hex, sizeof(hex), oid);

	file = fopen(path, "w");
	if (file == NULL)
		return qg_error_string(err, -1, "cannot write MERGE_HEAD");

	if (fprintf(file, "%s\n", hex) < 0) {
		fclose(file);
		return qg_error_string(err, -1, "cannot write MERGE_HEAD");
	}

	if (fclose(file) != 0)
		return qg_error_string(err, -1, "cannot write MERGE_HEAD");

	return 0;
}

static int qg_index_has_conflict(qg_repo *repo, int *out, qg_error *err)
{
	git_index *index = NULL;
	int rc;

	rc = git_repository_index(&index, repo->repo);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = git_index_has_conflicts(index);
	git_index_free(index);

	if (rc < 0)
		return qg_error_libgit2(err, rc);

	*out = rc;
	return 0;
}

/* Move the current branch (and the work tree) to target. */
static int qg_advance_branch(qg_repo *repo, const git_commit *target, qg_error *err)
{
	git_checkout_options options = GIT_CHECKOUT_OPTIONS_INIT;
	git_reference *head = NULL;
	git_reference *moved = NULL;
	const char *symbolic;
	char refname[1024];
	int rc;

	options.checkout_strategy = GIT_CHECKOUT_SAFE;

	rc = git_checkout_tree(repo->repo, (const git_object *)target, &options);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = git_reference_lookup(&head, repo->repo, "HEAD");
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	symbolic = git_reference_symbolic_target(head);
	if (symbolic == NULL) {
		git_reference_free(head);
		rc = git_repository_set_head_detached(repo->repo, git_commit_id(target));
	} else {
		snprintf(refname, sizeof(refname), "%s", symbolic);
		git_reference_free(head);
		rc = git_reference_create(&moved, repo->repo, refname, git_commit_id(target), 1,
		                          "qg_merge: fast-forward");
		git_reference_free(moved);
	}

	if (rc < 0)
		return qg_error_libgit2(err, rc);

	return 0;
}

static void qg_oid_out(char *out_oid, const git_oid *oid)
{
	if (out_oid != NULL)
		git_oid_tostr(out_oid, 41, oid);
}

int qg_merge(qg_repo *repo, const char *branch, const char *name, const char *email,
             int *out_result, char out_oid[41], qg_error *err)
{
	git_reference *reference = NULL;
	git_annotated_commit *theirs = NULL;
	git_object *object = NULL;
	git_commit *target = NULL;
	git_merge_analysis_t analysis;
	git_merge_preference_t preference;
	git_merge_options merge_options = GIT_MERGE_OPTIONS_INIT;
	git_checkout_options checkout_options = GIT_CHECKOUT_OPTIONS_INIT;
	const git_annotated_commit *heads[1];
	const git_oid *target_id;
	int conflicts = 0;
	int rc;

	if (repo == NULL || branch == NULL || out_result == NULL)
		return qg_invalid(err, "repo, branch and out_result are required");

	*out_result = 0;

	rc = git_branch_lookup(&reference, repo->repo, branch, GIT_BRANCH_LOCAL);
	if (rc == 0) {
		rc = git_annotated_commit_from_ref(&theirs, repo->repo, reference);
		git_reference_free(reference);
		if (rc < 0)
			return qg_error_libgit2(err, rc);
	} else {
		rc = git_revparse_single(&object, repo->repo, branch);
		if (rc < 0)
			return qg_error_libgit2(err, rc);

		rc = git_object_peel((git_object **)&target, object, GIT_OBJECT_COMMIT);
		git_object_free(object);
		if (rc < 0)
			return qg_error_libgit2(err, rc);

		rc = git_annotated_commit_lookup(&theirs, repo->repo, git_commit_id(target));
		git_commit_free(target);
		if (rc < 0)
			return qg_error_libgit2(err, rc);
	}

	heads[0] = theirs;
	target_id = git_annotated_commit_id(theirs);

	rc = git_merge_analysis(&analysis, &preference, repo->repo, heads, 1);
	if (rc < 0) {
		git_annotated_commit_free(theirs);
		return qg_error_libgit2(err, rc);
	}

	if (analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE) {
		*out_result = 0;
		qg_oid_out(out_oid, target_id);
		git_annotated_commit_free(theirs);
		return 0;
	}

	if ((analysis & GIT_MERGE_ANALYSIS_FASTFORWARD) || (analysis & GIT_MERGE_ANALYSIS_UNBORN)) {
		git_commit *commit = NULL;

		rc = git_commit_lookup(&commit, repo->repo, target_id);
		if (rc < 0) {
			git_annotated_commit_free(theirs);
			return qg_error_libgit2(err, rc);
		}

		rc = qg_advance_branch(repo, commit, err);
		if (rc == 0) {
			*out_result = 1;
			qg_oid_out(out_oid, target_id);
		}

		git_commit_free(commit);
		git_annotated_commit_free(theirs);
		return rc;
	}

	if ((analysis & GIT_MERGE_ANALYSIS_NORMAL) == 0) {
		git_annotated_commit_free(theirs);
		return qg_error_string(err, QG_EINVALID, "nothing to merge");
	}

	checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE;

	rc = git_merge(repo->repo, heads, 1, &merge_options, &checkout_options);
	if (rc < 0) {
		git_annotated_commit_free(theirs);
		return qg_error_libgit2(err, rc);
	}

	rc = qg_index_has_conflict(repo, &conflicts, err);

	if (rc == 0 && conflicts) {
		rc = qg_write_merge_head(repo, target_id, err);
		if (rc == 0) {
			*out_result = 3;
			qg_oid_out(out_oid, target_id);
		}
		git_annotated_commit_free(theirs);
		return rc;
	}

	if (rc == 0) {
		git_commit *commit = NULL;
		git_oid oid;
		char message[512];

		rc = git_commit_lookup(&commit, repo->repo, target_id);
		if (rc < 0) {
			git_annotated_commit_free(theirs);
			return qg_error_libgit2(err, rc);
		}

		snprintf(message, sizeof(message), "Merge branch '%s'", branch);

		rc = qg_write_commit(repo, message, name != NULL ? name : "qfli_git",
		                     email != NULL ? email : "qfli_git@localhost", commit, &oid, err);
		git_commit_free(commit);
		git_annotated_commit_free(theirs);

		if (rc < 0)
			return rc;

		*out_result = 2;
		qg_oid_out(out_oid, &oid);
		return 0;
	}

	git_annotated_commit_free(theirs);
	return rc;
}

typedef struct {
	git_oid items[8];
	size_t count;
	int overflow;
} qg_merge_heads;

static int qg_merge_head_cb(const git_oid *oid, void *payload)
{
	qg_merge_heads *heads = (qg_merge_heads *)payload;

	if (heads->count >= sizeof(heads->items) / sizeof(heads->items[0])) {
		heads->overflow = 1;
		return 0;
	}

	git_oid_cpy(&heads->items[heads->count++], oid);
	return 0;
}

int qg_merge_commit(qg_repo *repo, const char *message, const char *name, const char *email,
                    char out_oid[41], qg_error *err)
{
	qg_merge_heads heads;
	git_index *index = NULL;
	git_tree *tree = NULL;
	git_reference *head_ref = NULL;
	git_commit *parents[9];
	git_signature *signature = NULL;
	const git_commit *commit_parents[9];
	size_t parent_count = 0;
	size_t index_parent;
	git_oid oid;
	int conflicts = 0;
	int rc;

	if (repo == NULL || message == NULL)
		return qg_invalid(err, "repo and message are required");

	memset(&heads, 0, sizeof(heads));

	rc = git_repository_mergehead_foreach(repo->repo, qg_merge_head_cb, &heads);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	if (heads.count == 0)
		return qg_error_string(err, QG_EINVALID, "no merge in progress");

	if (heads.overflow)
		return qg_error_string(err, QG_EINVALID, "too many merge heads");

	rc = qg_index_has_conflict(repo, &conflicts, err);
	if (rc < 0)
		return rc;

	if (conflicts)
		return qg_error_string(err, QG_ECONFLICT, "index still has conflicts");

	rc = git_repository_index(&index, repo->repo);
	if (rc < 0)
		return qg_error_libgit2(err, rc);

	rc = qg_index_tree(&tree, index, repo->repo, err);
	git_index_free(index);
	if (rc < 0)
		return rc;

	rc = git_repository_head(&head_ref, repo->repo);
	if (rc < 0) {
		git_tree_free(tree);
		return qg_error_libgit2(err, rc);
	}

	rc = git_reference_peel((git_object **)&parents[0], head_ref, GIT_OBJECT_COMMIT);
	git_reference_free(head_ref);
	if (rc < 0) {
		git_tree_free(tree);
		return qg_error_libgit2(err, rc);
	}

	commit_parents[parent_count++] = parents[0];

	for (index_parent = 0; index_parent < heads.count; index_parent++) {
		rc = git_commit_lookup(&parents[parent_count], repo->repo, &heads.items[index_parent]);
		if (rc < 0)
			goto done;
		commit_parents[parent_count] = parents[parent_count];
		parent_count++;
	}

	rc = git_signature_now(&signature, name != NULL ? name : "qfli_git",
	                       email != NULL ? email : "qfli_git@localhost");
	if (rc < 0)
		goto done;

	rc = git_commit_create(&oid, repo->repo, "HEAD", signature, signature, NULL, message, tree,
	                       parent_count, commit_parents);
	if (rc < 0)
		goto done;

	rc = git_repository_state_cleanup(repo->repo);
	if (rc < 0)
		goto done;

	qg_oid_out(out_oid, &oid);

done:
	if (rc < 0)
		qg_error_libgit2(err, rc);

	git_signature_free(signature);
	for (index_parent = 0; index_parent < parent_count; index_parent++)
		git_commit_free(parents[index_parent]);
	git_tree_free(tree);

	return rc < 0 ? rc : 0;
}

/* ---------------------------------------------------------------------- */
/* inspection                                                              */
/* ---------------------------------------------------------------------- */

int qg_conflicts_json(qg_repo *repo, char **out_json, qg_error *err)
{
	git_index *index = NULL;
	git_index_conflict_iterator *iterator = NULL;
	qg_buffer buffer;
	const git_index_entry *ancestor = NULL;
	const git_index_entry *ours = NULL;
	const git_index_entry *theirs = NULL;
	char **seen = NULL;
	size_t seen_count = 0;
	int first = 1;
	int rc;

	if (repo == NULL || out_json == NULL)
		return qg_invalid(err, "repo and out_json are required");

	*out_json = NULL;
	memset(&buffer, 0, sizeof(buffer));

	if (qg_buffer_append(&buffer, "[") < 0) {
		rc = qg_error_string(err, -1, "out of memory");
		goto done;
	}

	rc = git_repository_index(&index, repo->repo);
	if (rc < 0) {
		qg_error_libgit2(err, rc);
		goto done;
	}

	rc = git_index_conflict_iterator_new(&iterator, index);
	if (rc < 0) {
		qg_error_libgit2(err, rc);
		goto done;
	}

	for (;;) {
		const git_index_entry *entry;
		const char *path;
		size_t index_seen;
		int duplicate = 0;

		rc = git_index_conflict_next(&ancestor, &ours, &theirs, iterator);
		if (rc == GIT_ITEROVER) {
			rc = 0;
			break;
		}
		if (rc < 0) {
			qg_error_libgit2(err, rc);
			goto done;
		}

		entry = ours != NULL ? ours : theirs;
		path = entry != NULL ? entry->path : NULL;

		if (path == NULL)
			continue;

		for (index_seen = 0; index_seen < seen_count; index_seen++) {
			if (strcmp(seen[index_seen], path) == 0) {
				duplicate = 1;
				break;
			}
		}
		if (duplicate)
			continue;

		seen = realloc(seen, sizeof(char *) * (seen_count + 1));
		if (seen == NULL) {
			rc = qg_error_string(err, -1, "out of memory");
			goto done;
		}
		seen[seen_count++] = (char *)path;

		if (!first && qg_buffer_append(&buffer, ",") < 0) {
			rc = qg_error_string(err, -1, "out of memory");
			goto done;
		}
		if (qg_buffer_append_json_string(&buffer, path) < 0) {
			rc = qg_error_string(err, -1, "out of memory");
			goto done;
		}
		first = 0;
	}

	if (qg_buffer_append(&buffer, "]") < 0) {
		rc = qg_error_string(err, -1, "out of memory");
		goto done;
	}

	if (qg_buffer_release(&buffer, out_json) < 0)
		rc = qg_error_string(err, -1, "out of memory");

done:
	free(seen);
	git_index_conflict_iterator_free(iterator);
	git_index_free(index);
	qg_buffer_dispose(&buffer);
	return rc;
}

static const char *qg_status_token(unsigned int status)
{
	if (status & GIT_STATUS_CONFLICTED)
		return "conflicted";
	if (status & GIT_STATUS_WT_NEW)
		return "worktree_new";
	if (status & GIT_STATUS_WT_RENAMED)
		return "worktree_renamed";
	if (status & GIT_STATUS_WT_MODIFIED)
		return "worktree_modified";
	if (status & GIT_STATUS_WT_DELETED)
		return "worktree_deleted";
	if (status & GIT_STATUS_WT_TYPECHANGE)
		return "worktree_typechange";
	if (status & GIT_STATUS_INDEX_NEW)
		return "index_new";
	if (status & GIT_STATUS_INDEX_RENAMED)
		return "index_renamed";
	if (status & GIT_STATUS_INDEX_MODIFIED)
		return "index_modified";
	if (status & GIT_STATUS_INDEX_DELETED)
		return "index_deleted";
	if (status & GIT_STATUS_INDEX_TYPECHANGE)
		return "index_typechange";
	if (status & GIT_STATUS_IGNORED)
		return "ignored";

	return "current";
}

int qg_status_json(qg_repo *repo, char **out_json, qg_error *err)
{
	git_status_options options = GIT_STATUS_OPTIONS_INIT;
	git_status_list *list = NULL;
	qg_buffer buffer;
	size_t count;
	size_t index;
	int rc = 0;

	if (repo == NULL || out_json == NULL)
		return qg_invalid(err, "repo and out_json are required");

	*out_json = NULL;
	memset(&buffer, 0, sizeof(buffer));

	options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
	options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;

	rc = git_status_list_new(&list, repo->repo, &options);
	if (rc < 0) {
		qg_error_libgit2(err, rc);
		goto done;
	}

	if (qg_buffer_append(&buffer, "[") < 0) {
		rc = qg_error_string(err, -1, "out of memory");
		goto done;
	}

	count = git_status_list_entrycount(list);

	for (index = 0; index < count; index++) {
		const git_status_entry *entry = git_status_byindex(list, index);
		const char *path;
		char bits[32];

		if (entry == NULL)
			continue;

		path = entry->head_to_index != NULL ? entry->head_to_index->old_file.path : NULL;
		if (path == NULL && entry->index_to_workdir != NULL)
			path = entry->index_to_workdir->old_file.path;
		if (path == NULL)
			continue;

		if (index > 0 && qg_buffer_append(&buffer, ",") < 0) {
			rc = qg_error_string(err, -1, "out of memory");
			goto done;
		}

		snprintf(bits, sizeof(bits), "%u", (unsigned int)entry->status);

		if (qg_buffer_append(&buffer, "{\"path\":") < 0 ||
		    qg_buffer_append_json_string(&buffer, path) < 0 ||
		    qg_buffer_append(&buffer, ",\"status\":\"") < 0 ||
		    qg_buffer_append(&buffer, qg_status_token((unsigned int)entry->status)) < 0 ||
		    qg_buffer_append(&buffer, "\",\"status_bits\":") < 0 ||
		    qg_buffer_append(&buffer, bits) < 0 ||
		    qg_buffer_append(&buffer, "}") < 0) {
			rc = qg_error_string(err, -1, "out of memory");
			goto done;
		}
	}

	if (qg_buffer_append(&buffer, "]") < 0) {
		rc = qg_error_string(err, -1, "out of memory");
		goto done;
	}

	if (qg_buffer_release(&buffer, out_json) < 0)
		rc = qg_error_string(err, -1, "out of memory");

done:
	git_status_list_free(list);
	qg_buffer_dispose(&buffer);
	return rc;
}

static const char *qg_state_token(int state)
{
	switch (state) {
	case GIT_REPOSITORY_STATE_MERGE:
		return "merge";
	case GIT_REPOSITORY_STATE_REVERT:
		return "revert";
	case GIT_REPOSITORY_STATE_REVERT_SEQUENCE:
		return "revert_sequence";
	case GIT_REPOSITORY_STATE_CHERRYPICK:
		return "cherrypick";
	case GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE:
		return "cherrypick_sequence";
	case GIT_REPOSITORY_STATE_BISECT:
		return "bisect";
	case GIT_REPOSITORY_STATE_REBASE:
		return "rebase";
	case GIT_REPOSITORY_STATE_REBASE_INTERACTIVE:
		return "rebase_interactive";
	case GIT_REPOSITORY_STATE_REBASE_MERGE:
		return "rebase_merge";
	case GIT_REPOSITORY_STATE_APPLY_MAILBOX:
		return "apply_mailbox";
	case GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE:
		return "apply_mailbox_or_rebase";
	default:
		return "none";
	}
}

int qg_head_json(qg_repo *repo, char **out_json, qg_error *err)
{
	qg_buffer buffer;
	git_reference *head = NULL;
	char branch[1024];
	char oid_hex[GIT_OID_SHA1_HEXSIZE + 1];
	const char *shorthand = NULL;
	int rc = 0;

	if (repo == NULL || out_json == NULL)
		return qg_invalid(err, "repo and out_json are required");

	*out_json = NULL;
	memset(&buffer, 0, sizeof(buffer));
	memset(oid_hex, 0, sizeof(oid_hex));

	rc = git_repository_head(&head, repo->repo);
	if (rc == 0) {
		shorthand = git_reference_shorthand(head);
		snprintf(branch, sizeof(branch), "%s", shorthand != NULL ? shorthand : "");

		if (git_reference_target(head) != NULL)
			git_oid_tostr(oid_hex, sizeof(oid_hex), git_reference_target(head));
		else {
			git_commit *commit = NULL;

			if (git_reference_peel((git_object **)&commit, head, GIT_OBJECT_COMMIT) == 0) {
				git_oid_tostr(oid_hex, sizeof(oid_hex), git_commit_id(commit));
				git_commit_free(commit);
			}
		}

		git_reference_free(head);
	} else if (rc == GIT_EUNBORNBRANCH) {
		git_reference *symbolic = NULL;

		branch[0] = '\0';
		if (git_reference_lookup(&symbolic, repo->repo, "HEAD") == 0) {
			const char *target = git_reference_symbolic_target(symbolic);

			if (target != NULL) {
				const char *prefix = "refs/heads/";

				if (strncmp(target, prefix, strlen(prefix)) == 0)
					snprintf(branch, sizeof(branch), "%s", target + strlen(prefix));
				else
					snprintf(branch, sizeof(branch), "%s", target);
			}
			git_reference_free(symbolic);
		}
	} else {
		return qg_error_libgit2(err, rc);
	}

	if (qg_buffer_append(&buffer, "{\"branch\":") < 0 ||
	    qg_buffer_append_json_string(&buffer, branch) < 0 ||
	    qg_buffer_append(&buffer, ",\"oid\":\"") < 0 ||
	    qg_buffer_append(&buffer, oid_hex) < 0 ||
	    qg_buffer_append(&buffer, "\",\"state\":\"") < 0 ||
	    qg_buffer_append(&buffer, qg_state_token(git_repository_state(repo->repo))) < 0 ||
	    qg_buffer_append(&buffer, "\"}") < 0) {
		rc = qg_error_string(err, -1, "out of memory");
		goto done;
	}

	if (qg_buffer_release(&buffer, out_json) < 0)
		rc = qg_error_string(err, -1, "out of memory");

done:
	qg_buffer_dispose(&buffer);
	return rc;
}

void qg_string_free(char *s)
{
	free(s);
}
