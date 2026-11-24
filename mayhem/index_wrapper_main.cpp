// index_wrapper_main.cpp — runs one bowtie2 tool on one fuzzed input inside a private scratch dir.
//
// Linked into copies of bowtie2-align-s / bowtie2-build-s / bowtie2-inspect-s whose own main() was
// renamed to bt2_original_main (-Dmain=bt2_original_main on the upstream compile; this TU is
// compiled separately so its main stays main). It serves two purposes:
//
//  * Fuzzing ONE file of a bowtie2 index. An index is six files sharing a basename (<base>.1.bt2,
//    .2.bt2, .3.bt2, .4.bt2, .rev.1.bt2, .rev.2.bt2) and the tools take the basename, not a file.
//    With <fixed-base> given, the fuzzed input is copied to <dir>/x<suffix> and the other five
//    files of the fixed index <fixed-base>.*.bt2 are symlinked next to it; every literal "@IDX@"
//    argument becomes <dir>/x.
//  * Containing output. The tool runs with <dir> as its cwd, so relative output paths a fuzzed
//    input picks (bowtie2-build's output basename, -S/--un/--al/--met-file in an -A args file)
//    land in <dir>, and <dir> is removed recursively after the run. Every literal "@FILE@"
//    argument becomes the absolute path of the fuzzed input.
//
// Scratch dirs are named <TMPDIR>/bt2idx.<pid>.XXXXXX. A run that aborts (a sanitizer halt, an
// upstream assert) skips cleanup, so each start first removes the dirs of processes that no
// longer exist.
//
// Usage: <wrapper> <fixed-index-basename | -> <suffix | -> <fuzzed file> <tool args ...>
#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <dirent.h>
#include <ftw.h>
#include <sys/types.h>
#include <unistd.h>

int bt2_original_main(int argc, MAIN_ARGV_T argv);

static std::string g_dir;

static int rm_entry(const char *path, const struct stat *, int, struct FTW *) {
	remove(path);
	return 0;
}

static void rm_tree(const std::string &d) {
	nftw(d.c_str(), rm_entry, 16, FTW_DEPTH | FTW_PHYS);
}

static void cleanup() {
	if (g_dir.empty()) return;
	if (chdir("/") != 0) { /* nothing useful to do */ }
	rm_tree(g_dir);
	g_dir.clear();
}

// Remove <tmp>/bt2idx.<pid>.* dirs whose process is gone (left behind by aborted runs).
static void sweep_stale(const std::string &tmp) {
	DIR *d = opendir(tmp.c_str());
	if (!d) return;
	std::vector<std::string> stale;
	while (struct dirent *e = readdir(d)) {
		if (strncmp(e->d_name, "bt2idx.", 7) != 0) continue;
		char *end = nullptr;
		long pid = strtol(e->d_name + 7, &end, 10);
		if (end == e->d_name + 7 || *end != '.' || pid <= 0) continue;
		if (pid == (long)getpid()) continue;
		if (kill((pid_t)pid, 0) == 0 || errno != ESRCH) continue;
		stale.push_back(tmp + "/" + e->d_name);
	}
	closedir(d);
	for (const std::string &s : stale) rm_tree(s);
}

static bool copy_file(const char *from, const std::string &to) {
	FILE *in = fopen(from, "rb");
	if (!in) return false;
	FILE *out = fopen(to.c_str(), "wb");
	if (!out) { fclose(in); return false; }
	char buf[65536];
	size_t n;
	bool ok = true;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0)
		if (fwrite(buf, 1, n, out) != n) { ok = false; break; }
	fclose(in);
	if (fclose(out) != 0) ok = false;
	return ok;
}

int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "usage: %s <fixed-index-base|-> <suffix|-> <fuzzed file> <args with @IDX@/@FILE@...>\n", argv[0]);
		return 2;
	}
	const bool use_index = strcmp(argv[1], "-") != 0;
	const std::string suffix = argv[2];
	static const char *sfx[] = {".1.bt2", ".2.bt2", ".3.bt2", ".4.bt2", ".rev.1.bt2", ".rev.2.bt2"};
	if (use_index) {
		bool known = false;
		for (const char *s : sfx) known = known || suffix == s;
		if (!known) { fprintf(stderr, "unknown index suffix '%s'\n", argv[2]); return 2; }
	}
	char fuzzed[PATH_MAX];
	if (!realpath(argv[3], fuzzed)) { perror("realpath input"); return 2; }

	const char *tmpenv = getenv("TMPDIR");
	std::string tmp = (tmpenv && *tmpenv) ? tmpenv : "/tmp";
	sweep_stale(tmp);
	std::string tmpl = tmp + "/bt2idx." + std::to_string((long)getpid()) + ".XXXXXX";
	std::vector<char> t(tmpl.begin(), tmpl.end());
	t.push_back('\0');
	if (!mkdtemp(t.data())) { perror("mkdtemp"); return 2; }
	g_dir = t.data();
	atexit(cleanup);
	if (chdir(g_dir.c_str()) != 0) { perror("chdir"); return 2; }

	std::string base = g_dir + "/x";
	if (use_index) {
		if (!copy_file(fuzzed, base + suffix)) { perror("copy input"); return 2; }
		for (const char *s : sfx) {
			if (suffix == s) continue;
			std::string target = std::string(argv[1]) + s;
			if (symlink(target.c_str(), (base + s).c_str()) != 0) { perror("symlink"); return 2; }
		}
	}
	std::vector<char *> args;
	args.push_back(argv[0]);
	for (int i = 4; i < argc; i++) {
		if (use_index && strcmp(argv[i], "@IDX@") == 0) args.push_back(const_cast<char *>(base.c_str()));
		else if (strcmp(argv[i], "@FILE@") == 0) args.push_back(fuzzed);
		else args.push_back(argv[i]);
	}
	args.push_back(nullptr);
	int rc = bt2_original_main((int)args.size() - 1, (MAIN_ARGV_T)args.data());
	cleanup();
	return rc;
}
