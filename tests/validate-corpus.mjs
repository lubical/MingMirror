// 语料库校验器：零依赖，供测试与命令行使用。
// 声部白名单与困境白名单与设计文档 §8 / 本计划文件结构节保持一致。
export const VOICES = ['laozi', 'lunyu', 'tanjing', 'mao', 'kapital', 'chuanxi', 'zhuangzi', 'stoic', 'frankl', 'zhuan-yi'];
export const DILEMMAS = ['意义与方向危机', '工作倦怠与异化', '焦虑与精神内耗', '人际与情感困扰', '欲望与物质匮乏感'];
const REQUIRED = ['id', '原文', '出处', '白话解析', '适用场景', '禁用场景', '关联声部'];

export function validateCorpus(entries) {
  const errors = [];
  const seen = new Set();
  for (const entry of entries) {
    for (const field of REQUIRED) {
      if (!(field in entry) || entry[field] === '' || (Array.isArray(entry[field]) && entry[field].length === 0 && field !== '禁用场景')) {
        errors.push(`[${entry.id ?? '??'}] 缺失字段: ${field}`);
      }
    }
    if (seen.has(entry.id)) errors.push(`[${entry.id}] 重复 id`);
    seen.add(entry.id);
    if (!VOICES.includes(entry['关联声部'])) errors.push(`[${entry.id}] 非法声部: ${entry['关联声部']}`);
    for (const d of entry['适用场景'] ?? []) {
      if (!DILEMMAS.includes(d)) errors.push(`[${entry.id}] 非法困境类型: ${d}`);
    }
    for (const d of entry['禁用场景'] ?? []) {
      if (!DILEMMAS.includes(d) && !d.includes('——') && d !== '') {
        errors.push(`[${entry.id}] 禁用场景应为困境类型或含解释的字符串: ${d}`);
      }
    }
  }
  return errors;
}

export function validateConcepts(entries, corpusIds) {
  const errors = [];
  const seen = new Set();
  const conceptIds = new Set(entries.map(e => e.id));
  for (const entry of entries) {
    for (const field of ['id', 'name', '声部', '定义', '关联语料']) {
      if (!(field in entry) || entry[field] === '' || (Array.isArray(entry[field]) && entry[field].length === 0)) {
        errors.push(`[concept:${entry.id ?? '??'}] 缺失字段: ${field}`);
      }
    }
    if (seen.has(entry.id)) errors.push(`[concept:${entry.id}] 重复 id`);
    seen.add(entry.id);
    if (!VOICES.includes(entry['声部'])) errors.push(`[concept:${entry.id}] 非法声部: ${entry['声部']}`);
    for (const cid of entry['关联语料'] ?? []) {
      if (!corpusIds.has(cid)) errors.push(`[concept:${entry.id}] 关联语料悬空: ${cid}`);
    }
    for (const rid of entry['关联概念'] ?? []) {
      if (!conceptIds.has(rid)) errors.push(`[concept:${entry.id}] 关联概念悬空: ${rid}`);
    }
  }
  return errors;
}

// 命令行入口：node tests/validate-corpus.mjs corpus concepts
import { pathToFileURL } from 'node:url';
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  import('node:fs').then(({ readdirSync, readFileSync }) => {
    const dirs = process.argv.slice(2).length ? process.argv.slice(2) : ['corpus'];
    const all = [];
    for (const dir of dirs) {
      for (const f of readdirSync(dir).filter(f => f.endsWith('.json'))) {
        all.push(...JSON.parse(readFileSync(`${dir}/${f}`, 'utf8')));
      }
    }
    const corpus = all.filter(e => !String(e.id).startsWith('concept-'));
    const concepts = all.filter(e => String(e.id).startsWith('concept-'));
    const corpusIds = new Set(corpus.map(e => e.id));
    const errors = [...validateCorpus(corpus), ...validateConcepts(concepts, corpusIds)];
    if (errors.length) {
      console.error(`✗ ${errors.length} 个错误:`);
      for (const e of errors) console.error(`  ${e}`);
      process.exit(1);
    }
    console.log(`✓ ${corpus.length} 条语料 + ${concepts.length} 条概念全部合法（${dirs.join(' + ')}）`);
  });
}
