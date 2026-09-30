import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { analyzeCommits } from '@semantic-release/commit-analyzer';
import { success, fail } from '@semantic-release/github';
import semanticRelease from 'semantic-release';
import config from '../release.config.cjs';

const logger = { log() {}, warn() {}, error() {}, success() {} };
const analyzer = config.plugins[0][1];

for (const [name, messages, expected] of [
  ['ordinary fix', ['fix: correct lookup'], 'patch'],
  ['documentation-only push', ['docs: explain installation'], 'patch'],
  ['CI-only empty-tree commit', ['ci: rerun release'], 'patch'],
  ['nonconventional commit', ['Update translations'], 'patch'],
  ['feature beats patch fallback', ['docs: examples', 'feat: new lookup'], 'minor'],
  ['breaking footer beats feature', ['feat: lookup\n\nBREAKING CHANGE: remove old API'], 'major'],
  ['breaking hyphenated footer', ['fix: lookup\n\nBREAKING-CHANGE: remove old API'], 'major'],
  ['bang header', ['feat!: replace lookup'], 'major'],
  ['scoped bang header', ['fix(api)!: remove old API'], 'major'],
  ['no new commits on rerun', [], null],
]) {
  test(name, async () => {
    const commits = messages.map((message, index) => ({ message, hash: String(index).padStart(40, '0') }));
    assert.equal(await analyzeCommits(analyzer, { commits, logger, cwd: process.cwd() }), expected);
  });
}

// Enforce the token permission contract at the official plugin's API boundary.
test('GitHub success/failure hooks require no issue or PR endpoints', async () => {
  const requests = [];
  class ReadOnlyOctokit {
    async request(route) {
      requests.push(route);
      assert.equal(route, 'GET /repos/{owner}/{repo}');
      return { data: {
        full_name: 'abs3ntdev/xray.koplugin',
        clone_url: config.repositoryUrl,
        permissions: { push: true },
      } };
    }
  }
  const context = {
    env: { GITHUB_TOKEN: 'local-test-placeholder' },
    options: { repositoryUrl: config.repositoryUrl },
    logger,
    commits: [{ hash: 'a'.repeat(40), message: 'fix: a change' }],
    nextRelease: { version: '26.9.30', gitTag: 'v26.9.30' },
    releases: [], errors: [], branch: { name: 'main' },
  };
  await success(config.plugins[2][1], context, { Octokit: ReadOnlyOctokit });
  await fail(config.plugins[2][1], context, { Octokit: ReadOnlyOctokit });
  assert.ok(requests.length > 0);
});

// Exercise maintained semantic-release itself with real local Git remotes.
// No GitHub calls, tokens, production tag writes or mock version allocator.
test('real semantic-release preserves baseline, exact SHA, reruns and stale-head guard', async (t) => {
  const root = await mkdtemp(join(process.env.JCODE_SCRATCH_DIR || tmpdir(), 'xray-semrel-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const remote = join(root, 'remote.git');
  const work = join(root, 'work');
  const other = join(root, 'other');
  const env = {
    PATH: process.env.PATH,
    HOME: root,
    XDG_CONFIG_HOME: root,
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: 'Release Test', GIT_AUTHOR_EMAIL: 'release@example.invalid',
    GIT_COMMITTER_NAME: 'Release Test', GIT_COMMITTER_EMAIL: 'release@example.invalid',
    CI: 'true', GITHUB_ACTIONS: 'true', GITHUB_REF: 'refs/heads/main',
    GITHUB_EVENT_NAME: 'push', GITHUB_REPOSITORY: 'local/fixture',
  };
  const git = (cwd, ...args) => execFileSync('git', args, { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git(root, 'init', '--bare', '--initial-branch=main', remote);
  git(root, 'clone', remote, work);
  git(work, 'commit', '--allow-empty', '-m', 'chore: baseline');
  git(work, 'tag', 'v26.9.29');
  git(work, 'push', 'origin', 'main', '--tags');
  git(work, 'commit', '--allow-empty', '-m', 'docs: describe release policy');
  git(work, 'push', 'origin', 'main');
  const pushedSHA = git(work, 'rev-parse', 'HEAD');
  git(work, 'checkout', '--detach', pushedSHA);
  const options = {
    ...config,
    repositoryUrl: `file://${remote}`,
    // Publishing to GitHub is the only excluded integration boundary.
    plugins: config.plugins.slice(0, 2),
  };
  const result = await semanticRelease(options, { cwd: work, env });
  assert.equal(result.nextRelease.version, '26.9.30');
  assert.equal(result.nextRelease.gitTag, 'v26.9.30');
  assert.equal(result.nextRelease.gitHead, pushedSHA);
  assert.equal(git(root, '--git-dir', remote, 'rev-parse', 'v26.9.30'), pushedSHA);
  const before = git(root, '--git-dir', remote, 'show-ref', '--tags');
  assert.equal(await semanticRelease(options, { cwd: work, env }), false);
  assert.equal(git(root, '--git-dir', remote, 'show-ref', '--tags'), before);

  git(root, 'clone', remote, other);
  git(other, 'commit', '--allow-empty', '-m', 'feat: newer pushed change');
  git(other, 'push', 'origin', 'main');
  // A queued old SHA must not be relabeled as the new branch-tip payload.
  assert.equal(await semanticRelease(options, { cwd: work, env }), false);
  assert.equal(git(work, 'rev-parse', 'HEAD'), pushedSHA);
  assert.equal(git(root, '--git-dir', remote, 'show-ref', '--tags'), before);
  const newer = await semanticRelease(options, { cwd: other, env });
  assert.equal(newer.nextRelease.version, '26.10.0');
  assert.equal(git(root, '--git-dir', remote, 'rev-parse', 'v26.10.0'), git(other, 'rev-parse', 'HEAD'));
});
