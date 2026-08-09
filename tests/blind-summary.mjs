import { readFileSync } from 'node:fs';

const lines = readFileSync('eval/blind-results-2026-08-09.jsonl', 'utf8').trim().split('\n');
for (const l of lines) {
  const j = JSON.parse(l);
  const out = j.output.replace(/\n+/g, ' ').slice(0, 120);
  console.log(`\n=== ${j.case}-${j.group}${j.safety_route ? ' [安全路由]' : ''} ===`);
  console.log(`输入: ${j.input.slice(0, 40)}`);
  console.log(`输出: ${out}`);
}
