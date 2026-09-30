// Select a published stable release at this exact checkout. Version images
// remain repairable after main advances; only the latest image tag is gated.
// Use the original workflow because GITHUB_TOKEN releases do not trigger others.
import { execFileSync } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const stableTag = /^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/;
export function selectRelease({ sha, tags, release, latestRelease }) {
  if (!/^[a-f0-9]{40}$/.test(sha || '') || !release
    || release.draft || release.prerelease || !release.published_at) return null;
  const tag = release.tag_name;
  if (!stableTag.test(tag || '') || !tags.includes(tag)) return null;
  const publishLatest = latestRelease?.tag_name === tag && !latestRelease.draft
    && !latestRelease.prerelease && Boolean(latestRelease.published_at);
  return { tag, version: tag.slice(1), sha, publishLatest };
}

export async function publishMetadata(env = process.env) {
  const sha = env.GITHUB_SHA, repo = env.GITHUB_REPOSITORY;
  if (!/^[a-f0-9]{40}$/.test(sha || '') || !/^[\w.-]+\/[\w.-]+$/.test(repo || '')
    || !env.GITHUB_TOKEN || !env.GITHUB_OUTPUT) throw new Error('Missing release workflow context');
  const head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  if (head !== sha) throw new Error('Release checkout does not match pushed commit');
  const tags = execFileSync('git', ['tag', '--points-at', sha, '--sort=-version:refname'], { encoding: 'utf8' })
    .trim().split('\n').filter(tag => stableTag.test(tag));
  const expected = env.EXPECTED_RELEASE_TAG;
  if (expected && (!stableTag.test(expected) || !tags.includes(expected))) throw new Error('Expected release does not match checkout');
  const get = async path => {
    const res = await fetch(`https://api.github.com/repos/${repo}/${path}`, {
      headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${env.GITHUB_TOKEN}`, 'X-GitHub-Api-Version': '2022-11-28' },
      redirect: 'error', signal: AbortSignal.timeout(15000),
    });
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`Release metadata request failed (${res.status})`);
    return res.json();
  };
  const latestRelease = await get('releases/latest');
  let selected;
  for (const tag of expected ? [expected] : tags) {
    const release = await get(`releases/tags/${encodeURIComponent(tag)}`);
    // The endpoint and response must identify the same exact checkout tag.
    if (release?.tag_name !== tag) continue;
    selected = selectRelease({ sha, tags, release, latestRelease });
    if (selected) break;
  }
  if (!selected) { console.log('No published stable release at this exact commit; skipping image publication.'); return; }
  await appendFile(env.GITHUB_OUTPUT, `release_tag=${selected.tag}\nrelease_version=${selected.version}\npublish_latest=${selected.publishLatest}\n`);
  console.log(`Image release selected: ${selected.tag}; publish latest: ${selected.publishLatest}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  publishMetadata().catch(() => { console.error('Could not verify release metadata; image publication stopped.'); process.exitCode = 1; });
}
