import assert from 'node:assert/strict';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { selectRelease } from './relay-release-metadata.mjs';
const sha = 'a'.repeat(40);
const fixture = () => ({ sha, tags: ['v26.10.0'], release: {
  tag_name: 'v26.10.0', draft: false, prerelease: false, published_at: '2026-09-30T00:00:00Z',
}, latestRelease: { tag_name: 'v26.10.0', draft: false, prerelease: false, published_at: '2026-09-30T00:00:00Z' } });
test('image uses exact published stable tag, including safe reruns', () => {
  assert.deepEqual(selectRelease(fixture()), { tag: 'v26.10.0', version: '26.10.0', sha, publishLatest: true });
  for (const patch of [{ sha: 'bad' }, { tags: ['v26.9.99'] }, { release: null }]) {
    assert.equal(selectRelease({ ...fixture(), ...patch }), null);
  }
  for (const patch of [{ draft: true }, { prerelease: true }, { published_at: null },
    { tag_name: 'v26.10.0-beta' }, { tag_name: 'v26.10.0\nlatest' }, { tag_name: 'v026.10.0' }]) {
    const input = fixture(); input.release = { ...input.release, ...patch };
    assert.equal(selectRelease(input), null);
  }
});
test('main advancing never suppresses a published version image', () => {
  assert.equal(selectRelease({ ...fixture(), mainSha: 'b'.repeat(40) }).publishLatest, true);
});
test('an older release rerun repairs version tags without rolling latest back', () => {
  const input = fixture();
  input.latestRelease = { ...input.latestRelease, tag_name: 'v26.11.0' };
  assert.deepEqual(selectRelease(input), { tag: 'v26.10.0', version: '26.10.0', sha, publishLatest: false });
  for (const latestRelease of [null, { ...input.release, draft: true }, { ...input.release, prerelease: true }]) {
    assert.equal(selectRelease({ ...fixture(), latestRelease }).publishLatest, false);
  }
});
test('release image job is gated and PR workflow cannot publish', async () => {
  const release = await readFile(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
  const pr = await readFile(new URL('../.github/workflows/relay-checks.yml', import.meta.url), 'utf8');
  assert.match(release, /needs: build/);
  assert.match(release, /docker build -t xray-relay:test \./);
  assert.ok(release.indexOf('docker build -t xray-relay:test .') < release.indexOf('run: npm run release'));
  assert.match(pr, /docker build -t xray-relay:test \./);
  for (const workflow of [release, pr]) {
    assert.doesNotMatch(workflow, /npm run test:|luajit tools\/spec_runner\.lua|bash tools\/smoke-relay-image\.sh/);
    assert.doesNotMatch(workflow, /apt-get install.*luajit/);
  }
  assert.match(release, /needs.build.outputs.release_tag != ''/);
  assert.match(release, /packages: write/);
  assert.match(release, /tools\/relay-release-metadata.mjs/);
  assert.equal((release.match(/node tools\/relay-release-metadata.mjs/g) || []).length, 2);
  assert.match(release, /if: steps.confirm-release.outputs.release_tag != ''/);
  assert.match(release, /EXPECTED_RELEASE_TAG: \$\{\{ needs.build.outputs.release_tag \}\}/);
  assert.match(release, /steps.confirm-release.outputs.publish_latest == 'true'/);
  assert.match(release, /refs\/tags\/\$\{\{ needs.build.outputs.release_tag \}\}/);
  assert.doesNotMatch(pr, /packages: write|push: true|secrets\./);
  assert.match(pr, /pull_request:/);
});

test('metadata selects an exact older release and emits version-only publication on rerun', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'xray-image-metadata-'));
  const git = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8' }).trim();
  try {
    git('init', '-q');
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '--allow-empty', '-qm', 'test');
    git('tag', 'v26.10.0');
    const commit = git('rev-parse', 'HEAD');
    const output = join(dir, 'outputs');
    const moduleUrl = new URL('./relay-release-metadata.mjs', import.meta.url).href;
    const script = `
      import { publishMetadata } from ${JSON.stringify(moduleUrl)};
      const release = { tag_name: 'v26.10.0', published_at: '2026-09-30', draft: false, prerelease: false };
      globalThis.fetch = async url => {
        if (url.endsWith('/releases/latest')) return Response.json({ ...release, tag_name: 'v26.11.0' });
        if (url.endsWith('/releases/tags/v26.10.0')) return Response.json(release);
        throw new Error('Unexpected request: ' + url);
      };
      await publishMetadata();
    `;
    const env = { ...process.env, GITHUB_SHA: commit, GITHUB_REPOSITORY: 'owner/repo',
      GITHUB_TOKEN: 'dummy-only', GITHUB_OUTPUT: output, EXPECTED_RELEASE_TAG: 'v26.10.0' };
    execFileSync(process.execPath, ['--input-type=module', '-e', script], { cwd: dir, env });
    assert.equal(await readFile(output, 'utf8'), 'release_tag=v26.10.0\nrelease_version=26.10.0\npublish_latest=false\n');
    assert.throws(() => execFileSync(process.execPath, ['--input-type=module', '-e', script], {
      cwd: dir, env: { ...env, EXPECTED_RELEASE_TAG: 'v26.11.0' }, stdio: 'pipe',
    }));
  } finally { await rm(dir, { recursive: true, force: true }); }
});
