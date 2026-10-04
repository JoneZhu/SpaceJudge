import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const guide = read('App/SpaceJudgeApp/InstallationGuide.html');

test('guide is self-contained, non-executable and uses a restrictive CSP', () => {
  assert.match(guide, /lang="zh-CN"/);
  assert.match(guide, /default-src 'none'/);
  assert.doesNotMatch(guide, /<script\b|\son\w+\s*=|<iframe\b|<form\b|<link\b|<img\b|url\s*\(/i);
});

test('local navigation targets exist and references are explicit trusted URLs', () => {
  const references = [...guide.matchAll(/href="([^"]+)"/g)].map(m => m[1]);
  for (const href of references) {
    if (href.startsWith('#')) assert.ok(guide.includes(`id="${href.slice(1)}"`), href);
    else assert.ok([
      'https://support.apple.com/zh-cn/102445',
      'https://support.apple.com/zh-cn/guide/mac-help/mchl211c911f/mac',
      'https://github.com/JoneZhu/SpaceJudge/issues',
      'https://github.com/JoneZhu/SpaceJudge/releases'
    ].includes(href), href);
  }
  assert.equal(references.filter(x => x.startsWith('#')).length, 5);
});

test('guide keeps safety disclosure and distinguishes launch, access and failures', () => {
  for (const text of ['未经过 Apple 公证', '不是 Apple Developer ID', '完全磁盘访问权限',
    '这不一定是权限问题', '停止尝试强行放行', '不需要关闭 Gatekeeper', '不删除或修改扫描目标']) {
    assert.ok(guide.includes(text), text);
  }
  assert.match(guide, /操作位置示意/);
});

test('no permanent release banner; welcome has an explicit help entry', () => {
  const content = read('App/SpaceJudgeApp/ContentView.swift');
  assert.doesNotMatch(content, /experimental-build-notice|实验性测试版 · 未经过 Apple 公证/);
  assert.match(content, /accessibilityIdentifier\("installation-help"\)/);
  assert.match(content, /AppDelegate\.openInstallationGuide\(\)/);
});

test('help is a bundled resource and available independently of scan bootstrap', () => {
  assert.match(read('App/SpaceJudge.xcodeproj/project.pbxproj'), /InstallationGuide\.html in Resources/);
  const app = read('App/SpaceJudgeApp/SpaceJudgeApp.swift');
  assert.match(app, /CommandGroup\(replacing: \.help\)/);
  assert.match(app, /Button\("安装与权限帮助"\)/);
  assert.match(read('App/SpaceJudgeApp/AppDelegate.swift'), /Bundle\.main\.url\(forResource: "InstallationGuide", withExtension: "html"\)/);
});
