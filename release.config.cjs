const parserOpts = {
  headerPattern: /^(\w+)(?:\(([^)]*)\))?!?: (.+)$/,
  headerCorrespondence: ['type', 'scope', 'subject'],
  breakingHeaderPattern: /^(\w+)(?:\(([^)]*)\))?!: (.+)$/,
  noteKeywords: ['BREAKING CHANGE', 'BREAKING-CHANGE'],
};

module.exports = {
  branches: ['main'],
  repositoryUrl: 'https://github.com/abs3ntdev/xray.koplugin.git',
  tagFormat: 'v${version}',
  plugins: [
    ['@semantic-release/commit-analyzer', {
      parserOpts,
      releaseRules: [
        { breaking: true, release: 'major' },
        { type: 'feat', release: 'minor' },
        { release: 'patch' },
      ],
    }],
    ['@semantic-release/release-notes-generator', { parserOpts }],
    ['@semantic-release/github', {
      assets: [{ path: 'xray.koplugin.zip', label: 'Installable KOReader plugin' }],
      draftRelease: false,
      successComment: false,
      successCommentCondition: false,
      failComment: false,
      failCommentCondition: false,
      failTitle: false,
      labels: false,
      releasedLabels: false,
      addReleases: false,
    }],
  ],
};
