import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { validateCorpus } from './validate-corpus.mjs';

function load(name) {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
}

test('合法语料通过校验', () => {
  const errors = validateCorpus(load('sample-ok.json'));
  assert.deepEqual(errors, []);
});

test('非法语料报出全部错误', () => {
  const errors = validateCorpus(load('sample-bad.json'));
  assert.ok(errors.some(e => e.includes('非法困境类型')), `应报非法困境类型，实际：${errors}`);
  assert.ok(errors.some(e => e.includes('非法声部')), `应报非法声部，实际：${errors}`);
  assert.ok(errors.some(e => e.includes('重复 id')), `应报重复 id，实际：${errors}`);
  assert.ok(errors.some(e => e.includes('缺失字段')), `应报缺失字段，实际：${errors}`);
});
